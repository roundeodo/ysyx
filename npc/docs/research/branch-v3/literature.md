# 文献与实际借鉴边界

下面区分读过、运行过和实现过。论文中的准确率、功耗或频率不是本核的测量结果。

| 一手来源 | 原系统前提 | 本轮状态与用途 |
| --- | --- | --- |
| [Seznec，TAGE-SC-L Again，CBP 2016](https://jilp.org/cbp2016/paper/AndreSeznecLimited.pdf)；[作者程序](https://jilp.org/cbp2016/code/AndreSeznecLimited.tar.gz) | 名义8/64KB、竞赛轨迹；方向/路径和局部特征，SC、loop及选择器共同工作 | 论文与8KB源码已阅读；未修改作者predictor.h并运行开发轨迹。新RTL借鉴最长匹配/alternate、有符号counter、useful、分配、增量折叠、SC中心化求和与loop；不是原配置缩小倍率后的等价物 |
| [MORSL，CBP-NG 2026](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/pdfs/Koizumi-CBP-NG%2726.pdf) | 37.5KiB；HARCOM；ahead流水、按block内rank预测至多4个条件分支；窄字tagged表、无求和tagged corrector、分配反馈的访问过滤 | 正文已核验。用于检查表宽、组合加法和访问过滤成本；本核没有block/rank前端。尚未实现该TC/访问过滤，也没有借用其能耗或时序数值 |
| [BOOM官方BPD说明](https://docs.boom-core.org/en/latest/sections/branch-prediction/backing-predictor.html) | 宽取指/OoO；推测历史、恢复快照、FTQ与提交训练各有职责 | 用于核对历史快照与训练时机必须分开。当前原型仍在解析时训练，未移植BOOM的FTQ/提交策略；漏历史需要显式恢复，不能仅判断next-PC |
| [Agree原始项目入口，Sprangle等，ISCA 1997](https://hps.ece.utexas.edu/hps_branchpred.html) | 动态表学习同意/反对偏置，目的是减少相反偏置的干扰 | H3为BTFNT偏置的模型变体；训练的是actual==saved_bias，不是taken。原文PS下载失败，故未标为原文完整复现 |
| [Ahead分支预测，ISCA 2025作者入口](https://hps.ece.utexas.edu/hps_branchpred.html) | 需要更早的PC/历史，预测吞吐和提前访问成为系统问题 | 已找到作者PDF，但下载超时；只列待深入阅读，未实现或引用具体收益 |
| [SmartScout，ICS 2026作者页面](https://craft.cs.tsinghua.edu.cn/publication/look-before-you-leap-precision-instruction-supply-via-smartscout/) | 利用验证时间与运行时过滤改进指令供给 | 仅核验作者摘要。本轮直接目标计算不是SmartScout实现，不能据此声称采用该论文算法 |

## 作者参考的核验口径

源码压缩包哈希、URL和授权情况在`author-artifact.json`。`fetch_author.py`只下载到result，保留源码不修改；未发现明确再分发许可，因此不把压缩包加入Git。适配层只补竞赛枚举和未用到的trace头文件。

作者8KB配置自行输出的计数为67,349 bit，名义名称不等于恰好65,536 bit。它是机制参考，不是理论上界，也不是同面积RTL。当前测量包括ROI冷启动及真实不同请求的自然前缀，均为正确路径立即训练；调用/返回由真实指令字段分类，actual只传给更新接口。

第一版适配器只区分branch/JAL/JALR，第二版补齐direct call、indirect call、return分类。两个结果文件都保留；应使用v2，不据结果相同推断分类无关。自然前缀另见author-warmup.json：两种软件、冷/暖窗口、开发/验证输入共16组。标准作者竞赛轨迹复跑与延迟训练适配尚未完成；不能在多条未决查询中直接复用作者实现的临时全局变量。

## 新RTL保留了什么

`riscv32_tage_scl`是base32、3×16 tagged、3/7/16方向历史的独立实验实现，非旧T16改名。SC和loop均有独立开关；解析/推测历史分开检查。SC只有三个小表和一个阈值，loop没有作者实现的完整age/替换策略；尚无local/path/IMLI特征、bank interleaving或按实际访问门控的节能实验。

这些裁剪是当前原型边界，不是已经证明最优的组织。表数2/3、tag6至10bit、history组、base16至128项、tagged8至64项已独立参数化；8组RTL几何、3个seed、每组4000事件完成96,000次全状态比较。更多特征和loop age仍是未实现项。

## 进一步核验的嵌入式参考

[CVA6S+作者论文，RISC-V Summit Europe 2025](https://arxiv.org/html/2505.03762v1)描述了128项、每项3bit私有历史的两级方向预测。它的基底是双发射CVA6S，I$16KiB、D$32KiB，评测Embench-IoT与RaiderSTREAM；不是本核1KiB/256B缓存配置，也没有把该文整体IPC提升归到预测器。本轮另建有限容量LocalHistory模型，保存查询时历史用于PHT训练，和gshare的全局历史明确分开；尚未复刻CVA6S+ RTL。

[Ahead ISCA 2025作者PDF](https://hps.ece.utexas.edu/pub/cai_ahead.pdf)的搜索索引可核验“给缺失历史模式加tag”的思路，但直接全文获取仍超时；不能据搜索摘要声称读完整篇或实现。它需要提前PC与遗漏历史的组织，本轮不把请求侧单拍TAGE改名为ahead predictor。

## 间接目标与寄存器相关方向

[Seznec ITTAGE，JWAC-2/CBP 2011](https://jilp.org/jwac-2/program/cbp3_07_seznec.pdf)已阅读全文：16逻辑表，最长匹配、弱置信alternate、useful与压力老化；目标区间表及IUM也有额外成本。文中约64KiB组织还用间接/调用路径信息，不能用单一方向bit代替。当前IndirectHistory只有last-target加两张小路径表，没有IUM、原分配和region组织，明确不称完整ITTAGE。新模型不如last-target，仅否决该已测小组织，不能否决全部ITTAGE。

[RUNLTS，ISCA 2026作者资料](https://www.rsg.ci.i.u-tokyo.ac.jp/members/shioya/)与[artifact DOI](https://doi.org/10.5281/zenodo.19453058)已核验入口；PDF获取超时、artifact页面未取得，未声称完整阅读/运行。寄存器相关预测与T7真实操作数提前解析不同；本轮只记录既有前递何时就绪，没有向lookup提供未来操作数。2025竞赛版本与2026主会版本也不混称同一artifact。

## BTB容量、索引、准入与替换补充

[Perleberg和Smith，BTB Design and Optimization，Berkeley 1989](https://www2.eecs.berkeley.edu/Pubs/TechRpts/1989/5904.html)
的学校原始摘要明确讨论taken时准入、相联度和替换。它支持将准入单独做对照，而不是把所有收益归给RRIP。
[RRIP，ISCA 2010作者PDF](https://jaleels.org/ajaleel/publications/isca2010-rrip.pdf)
针对cache复用/扫描模式，使用较少复用状态位；本核把2bit状态用于BTB，分配2、解析taken命中提升0、选最大值并老化。
查询不更新，未解析错误路径也不提升。它是经典机制的迁移，不是2026年新算法，也不是原论文应用场景的等价实现。

[MicroBTB，2021作者全文](https://arxiv.org/html/2106.04205)
将目标偏移压缩和每路不同索引联合设计，用于服务器的末级BTB；原系统有128项一级、8192项二级、FTQ与FDIP、57bit地址。
本轮已阅读其动机、组织与评测设置；当前新增异或/折叠索引对所有路使用同一个组号，**不是skewed BTB**，
也没有把16～128项单级表改名为MicroBTB。该文促使本轮分开比较容量、相联度、索引和压缩，不能迁移其服务器收益数字。
每路不同索引需要重新设计完整身份与替换写口，尚未实现；既有compact目标与本轮新索引组合显式拒绝，避免未验证混用。

## BTB替换与插入的扩展核验

[DIP/LIP/BIP，ISCA 2007作者论文](https://jaleels.org/ajaleel/publications/isca2007-dip.pdf)
将插入和命中提升分开，并通过组竞争选策略；原评测包含1MiB、16路L2和乱序核。
本轮将访问改为控制流解析，新项插入与taken命中提升独立比较；五位分配周期、五位选择器和两个leader
适应小BTB，但组数少、leader地址分布不均的限制必须保留。BRRIP/DRRIP按上述RRIP原文单独建模。

[SHiP，MICRO 2011作者论文](https://jaleels.org/ajaleel/publications/micro2011-SHiP.pdf)
已核验签名复用、计数表、复用位与插入规则；原对象是1MiB及四核共享4MiB LLC。
BTB原型使用分支PC四位折叠签名、16个二位counter；解析taken命中提供正反馈，未复用替换提供负反馈。
完整PC可从tag/组号恢复，因此RTL不另存每条签名。它不是原SHiP的LLC访问语义，也不是近年新论文。
模型含三种方向、六种BTB组织，RTL只深入16项折叠组织的一组匹配对照。

SmartScout作者摘要中的运行时噪声过滤促使本轮增加置信度过滤提示作为独立控制；
只使用已有BHT二位counter==3，不移植未核验的FTQ验证机制，也不伪造TAGE置信度。
退休taken、退休正确目标信用是本核定义的两种反馈边界，不能将它们当成同一个原论文算法。
全部14种策略、资源约定和结果见[替换扩展记录](btb-replacement-study.md)。
